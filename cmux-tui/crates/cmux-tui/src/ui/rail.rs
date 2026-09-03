//! Shared visual primitives for the machine and workspace rails.

use cmux_tui_core::Rect;
use ratatui::Frame;
use ratatui::style::{Color, Modifier, Style};

use super::truncate;
use crate::app::App;
use crate::config::ActionsPosition;

/// Configurable rail row geometry: `height` rows of content per entry and
/// `stride` rows from one entry's start to the next (height plus gap).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RailMetrics {
    pub height: usize,
    pub stride: usize,
}

impl RailMetrics {
    pub fn for_app(app: &App) -> Self {
        let height = app.config.sidebar.row_height.max(1) as usize;
        Self { height, stride: height + app.config.sidebar.row_gap as usize }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowSpan {
    pub start: usize,
    pub height: usize,
}

impl RowSpan {
    pub const fn new(start: usize, height: usize) -> Self {
        Self { start, height }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Viewport {
    pub body: Rect,
    pub footer: Rect,
    pub body_offset: usize,
    pub footer_offset: usize,
}

impl Viewport {
    pub fn body_y(self, span: RowSpan) -> Option<u16> {
        visible_y(self.body, self.body_offset, span)
    }

    pub fn footer_y(self, span: RowSpan) -> Option<u16> {
        visible_y(self.footer, self.footer_offset, span)
    }
}

/// Split a rail into a one-row top pad, a scrollable body, and a bottom-pinned
/// footer. Footer rows get first claim on short terminals, so every action can
/// be reached by keyboard even when the catalog itself has no visible rows.
pub fn viewport(
    area: Rect,
    body_rows: usize,
    footer_rows: usize,
    body_offset: &mut usize,
    footer_offset: &mut usize,
    selected_body: Option<RowSpan>,
    selected_footer: Option<RowSpan>,
) -> Viewport {
    viewport_positioned(
        area,
        body_rows,
        footer_rows,
        body_offset,
        footer_offset,
        selected_body,
        selected_footer,
        ActionsPosition::Bottom,
    )
}

/// `viewport` with a configurable action-row position: `Bottom` pins the
/// action rows to the rail's bottom edge, `Top` mounts them at the rail's
/// top with the scrollable body below.
#[allow(clippy::too_many_arguments)]
pub fn viewport_positioned(
    area: Rect,
    body_rows: usize,
    footer_rows: usize,
    body_offset: &mut usize,
    footer_offset: &mut usize,
    selected_body: Option<RowSpan>,
    selected_footer: Option<RowSpan>,
    position: ActionsPosition,
) -> Viewport {
    let available = area.height.saturating_sub(1);
    let footer_height = footer_rows.min(available as usize) as u16;
    let body_height = available.saturating_sub(footer_height);
    let (body_y, footer_y) = match position {
        ActionsPosition::Bottom => (
            area.y.saturating_add(1),
            area.y.saturating_add(area.height).saturating_sub(footer_height),
        ),
        ActionsPosition::Top => {
            (area.y.saturating_add(1).saturating_add(footer_height), area.y.saturating_add(1))
        }
    };
    let body = Rect { x: area.x, y: body_y, width: area.width, height: body_height };
    let footer = Rect { x: area.x, y: footer_y, width: area.width, height: footer_height };
    reveal(body_rows, body_height as usize, body_offset, selected_body);
    reveal(footer_rows, footer_height as usize, footer_offset, selected_footer);
    Viewport { body, footer, body_offset: *body_offset, footer_offset: *footer_offset }
}

fn reveal(total: usize, visible: usize, offset: &mut usize, selected: Option<RowSpan>) {
    *offset = (*offset).min(total.saturating_sub(visible));
    let Some(selected) = selected else { return };
    if visible == 0 {
        return;
    }
    let start = selected.start.min(total.saturating_sub(1));
    let end = selected.start.saturating_add(selected.height).min(total);
    if start < *offset {
        *offset = start;
    } else if end > offset.saturating_add(visible) {
        *offset = end.saturating_sub(visible);
    }
    *offset = (*offset).min(total.saturating_sub(visible));
}

fn visible_y(area: Rect, offset: usize, span: RowSpan) -> Option<u16> {
    if span.start < offset
        || span.start.saturating_add(span.height) > offset.saturating_add(area.height as usize)
    {
        return None;
    }
    Some(area.y.saturating_add((span.start - offset) as u16))
}

#[derive(Clone, Copy)]
pub struct RailPalette {
    pub base: Style,
    pub dim: Style,
    pub active: Style,
    pub border: Style,
    pub border_symbol: &'static str,
    pub rail: Color,
    /// Accent glyph on active rows; `None` draws none. A single character
    /// keeps the palette `Copy`, so drawing never borrows the app config.
    pub rail_glyph: Option<char>,
}

impl RailPalette {
    pub fn for_app(app: &App, focused: bool) -> Self {
        let chrome = app.chrome;
        let selected_bg = if app.config.theme_overrides.sidebar_active_bg {
            app.config.theme.sidebar_active_bg
        } else {
            chrome.sidebar_selected_bg
        };
        let selected_fg =
            app.config.theme.sidebar_selected_fg.unwrap_or(chrome.sidebar_selected_fg);
        let base = match app.config.theme.sidebar_fg {
            Some(fg) => Style::default().fg(fg),
            None => Style::default(),
        };
        Self {
            base,
            dim: base.fg(chrome.sidebar_dim_fg),
            active: Style::default().bg(selected_bg).fg(selected_fg).add_modifier(Modifier::BOLD),
            border: base
                .fg(if focused { app.config.theme.border_active } else { chrome.sidebar_border })
                .add_modifier(if focused { Modifier::BOLD } else { Modifier::empty() }),
            border_symbol: if focused { "┃" } else { "│" },
            rail: app.config.theme.sidebar_rail,
            rail_glyph: app.config.sidebar.rail_glyph.chars().next(),
        }
    }
}

pub fn prepare(frame: &mut Frame, area: Rect, palette: RailPalette) {
    if area.width < 3 || area.height == 0 {
        return;
    }
    let border_x = area.x + area.width - 1;
    let buf = frame.buffer_mut();
    for y in area.y..area.y + area.height {
        for x in area.x..border_x {
            buf[(x, y)].set_symbol(" ").set_style(palette.base);
        }
        buf[(border_x, y)].set_symbol(palette.border_symbol).set_style(palette.border);
    }
}

/// Draw a compact informational readout on the rail's top pad row, right
/// aligned and dimmed so it reads as chrome rather than as a selectable
/// entry. Skipped entirely when the rail is too narrow to show it whole.
pub fn header_readout(frame: &mut Frame, area: Rect, text: &str, palette: RailPalette) {
    if area.width < 3 || area.height == 0 {
        return;
    }
    let content_width = usize::from(area.width.saturating_sub(1));
    let width = unicode_width::UnicodeWidthStr::width(text);
    if width == 0 || width + 2 > content_width {
        return;
    }
    let x = area.x + (content_width - width - 1) as u16;
    frame.buffer_mut().set_stringn(x, area.y, text, width, palette.dim);
}

pub struct Entry<'a> {
    pub name: &'a str,
    pub subtitle: &'a str,
    pub highlighted: bool,
    pub active: bool,
    pub indicator: Option<Color>,
    pub dimmed: bool,
}

pub fn entry(
    frame: &mut Frame,
    area: Rect,
    y: u16,
    entry: Entry<'_>,
    palette: RailPalette,
    metrics: RailMetrics,
) {
    let rows = metrics.height.max(1) as u16;
    if area.width < 3 || y + rows > area.y + area.height {
        return;
    }
    let content_width = area.width.saturating_sub(1);
    let content_w = content_width as usize;
    let mut style = if entry.highlighted { palette.active } else { palette.base };
    if entry.dimmed {
        style = style.add_modifier(Modifier::DIM);
    }
    let subtitle_style =
        if entry.highlighted { palette.active.add_modifier(Modifier::DIM) } else { palette.dim };
    let buf = frame.buffer_mut();
    if entry.highlighted {
        for row in 0..rows {
            for x in area.x..area.x + content_width {
                buf[(x, y + row)].set_style(palette.active);
            }
        }
        if entry.active
            && let Some(glyph) = palette.rail_glyph
        {
            let mut encoded = [0u8; 4];
            let symbol: &str = glyph.encode_utf8(&mut encoded);
            let rail_style = palette.active.fg(palette.rail);
            for row in 0..rows {
                buf[(area.x, y + row)].set_symbol(symbol).set_style(rail_style);
            }
        }
    }
    let indicator = entry.indicator.filter(|_| content_w > 3);
    if let Some(color) = indicator {
        buf[(area.x + 1, y)]
            .set_symbol("•")
            .set_style(style.fg(color).add_modifier(Modifier::BOLD));
    }
    let name_offset = if indicator.is_some() { 3 } else { 1 };
    if content_w > name_offset {
        buf.set_stringn(
            area.x + name_offset as u16,
            y,
            truncate(entry.name, content_w - name_offset),
            content_w - name_offset,
            style,
        );
    }
    if rows >= 2 && content_w > 1 {
        buf.set_stringn(
            area.x + 1,
            y + 1,
            truncate(entry.subtitle, content_w - 1),
            content_w - 1,
            subtitle_style,
        );
    }
}

pub fn action(
    frame: &mut Frame,
    area: Rect,
    y: u16,
    label: &str,
    highlighted: bool,
    palette: RailPalette,
) {
    if y >= area.y + area.height || area.width < 2 {
        return;
    }
    let content_width = area.width.saturating_sub(1);
    let style = if highlighted { palette.active } else { palette.dim };
    if highlighted {
        for x in area.x..area.x + content_width {
            frame.buffer_mut()[(x, y)].set_symbol(" ").set_style(style);
        }
    }
    frame.buffer_mut().set_stringn(area.x, y, format!(" + {label}"), content_width as usize, style);
}

pub fn button(
    frame: &mut Frame,
    area: Rect,
    y: u16,
    label: &str,
    highlighted: bool,
    palette: RailPalette,
) {
    if y >= area.y + area.height || area.width < 2 {
        return;
    }
    let content_width = area.width.saturating_sub(1);
    let style = if highlighted { palette.active } else { palette.dim };
    if highlighted {
        for x in area.x..area.x + content_width {
            frame.buffer_mut()[(x, y)].set_symbol(" ").set_style(style);
        }
    }
    frame.buffer_mut().set_stringn(
        area.x + 1,
        y,
        truncate(label, content_width.saturating_sub(1) as usize),
        content_width.saturating_sub(1) as usize,
        style,
    );
}

/// Dense one-line row used by configurable resource trees. The returned
/// rectangle is the disclosure target when the row has children.
#[allow(clippy::too_many_arguments)]
pub fn tree_row(
    frame: &mut Frame,
    area: Rect,
    y: u16,
    depth: u16,
    name: &str,
    detail: &str,
    branch: Option<bool>,
    highlighted: bool,
    active: bool,
    palette: RailPalette,
) -> Option<Rect> {
    if y >= area.y.saturating_add(area.height) || area.width < 3 {
        return None;
    }
    let content_width = area.width.saturating_sub(1);
    let style = if highlighted { palette.active } else { palette.base };
    let detail_style =
        if highlighted { palette.active.add_modifier(Modifier::DIM) } else { palette.dim };
    let buf = frame.buffer_mut();
    if highlighted {
        for x in area.x..area.x.saturating_add(content_width) {
            buf[(x, y)].set_symbol(" ").set_style(style);
        }
    }
    if active && let Some(glyph) = palette.rail_glyph {
        let mut encoded = [0u8; 4];
        buf[(area.x, y)]
            .set_symbol(glyph.encode_utf8(&mut encoded))
            .set_style(style.fg(palette.rail));
    }
    let disclosure_x = area
        .x
        .saturating_add(1)
        .saturating_add(depth.saturating_mul(2))
        .min(area.x.saturating_add(content_width.saturating_sub(1)));
    let disclosure = branch.map(|expanded| {
        buf[(disclosure_x, y)].set_symbol(if expanded { "▾" } else { "▸" }).set_style(detail_style);
        Rect { x: disclosure_x, y, width: 1, height: 1 }
    });
    let name_x = disclosure_x.saturating_add(2);
    let available = area.x.saturating_add(content_width).saturating_sub(name_x) as usize;
    if available > 0 {
        let label = if detail.is_empty() { name.to_string() } else { format!("{name}  {detail}") };
        buf.set_stringn(name_x, y, truncate(&label, available), available, style);
    }
    disclosure
}

pub fn row(area: Rect, y: u16) -> Rect {
    Rect { x: area.x, y, width: area.width.saturating_sub(1), height: 1 }
}

pub fn divider(area: Rect) -> Rect {
    Rect { x: area.x + area.width.saturating_sub(1), y: area.y, width: 1, height: area.height }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    #[test]
    fn active_entry_keeps_the_shared_rail_when_it_has_a_status_indicator() {
        let mut terminal = Terminal::new(TestBackend::new(16, 3)).unwrap();
        let palette = RailPalette {
            base: Style::default(),
            dim: Style::default(),
            active: Style::default().add_modifier(Modifier::BOLD),
            border: Style::default(),
            border_symbol: "│",
            rail: Color::Cyan,
            rail_glyph: Some('▎'),
        };
        terminal
            .draw(|frame| {
                entry(
                    frame,
                    Rect { x: 0, y: 0, width: 16, height: 3 },
                    0,
                    Entry {
                        name: "machine",
                        subtitle: "running",
                        highlighted: true,
                        active: true,
                        indicator: Some(Color::Green),
                        dimmed: false,
                    },
                    palette,
                    RailMetrics { height: 2, stride: 3 },
                );
            })
            .unwrap();

        let buffer = terminal.backend().buffer();
        assert_eq!(buffer[(0, 0)].symbol(), "▎");
        assert_eq!(buffer[(0, 1)].symbol(), "▎");
        assert_eq!(buffer[(1, 0)].symbol(), "•");
        assert_eq!(buffer[(3, 0)].symbol(), "m");
        assert_eq!(buffer[(1, 1)].symbol(), "r");
    }

    #[test]
    fn short_viewport_pins_footer_and_keeps_selected_action_visible() {
        let area = Rect { x: 2, y: 3, width: 20, height: 3 };
        let mut body_offset = 0;
        let mut footer_offset = 0;
        let viewport = viewport(
            area,
            30,
            4,
            &mut body_offset,
            &mut footer_offset,
            None,
            Some(RowSpan::new(3, 1)),
        );

        assert_eq!(viewport.body.height, 0);
        assert_eq!(viewport.footer.height, 2);
        assert_eq!(viewport.footer.y, 4);
        assert_eq!(viewport.footer_offset, 2);
        assert_eq!(viewport.footer_y(RowSpan::new(3, 1)), Some(5));
    }

    #[test]
    fn resizing_clamps_scroll_without_forgetting_a_visible_selection() {
        let mut body_offset = 12;
        let mut footer_offset = 0;
        let selected = RowSpan::new(15, 2);
        let small = viewport(
            Rect { x: 0, y: 0, width: 20, height: 8 },
            30,
            2,
            &mut body_offset,
            &mut footer_offset,
            Some(selected),
            None,
        );
        assert!(small.body_y(selected).is_some());

        let large = viewport(
            Rect { x: 0, y: 0, width: 20, height: 20 },
            30,
            2,
            &mut body_offset,
            &mut footer_offset,
            Some(selected),
            None,
        );
        assert!(large.body_y(selected).is_some());
        assert_eq!(body_offset, 12);
    }
}
