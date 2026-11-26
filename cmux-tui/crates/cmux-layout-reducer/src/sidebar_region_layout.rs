//! The pinned sidebar bands' layout, moved from the app's `SectionFlow`,
//! `SidebarRegionLayout`, `SidebarRegionDrop` and `SidebarBandHeights`
//! (CmuxNextSidebar/Sections) with the same inputs and outputs.
//!
//! Pure: the sections of a band (the layout document's wire shape,
//! [`Section`]) and the sizes the app measured ([`Metrics`], label and icon
//! widths, app content heights) give every frame the band draws: headers,
//! list rows, tiles and chips on lines, cards, section lines and each
//! section's frame ([`RegionLayout`]). Drop-to-pin ([`drop_target`]) and the
//! two bands' heights ([`band_heights`]) read that layout. The app asks over
//! `cmux_layout_reducer_json` ops `sidebar_region_layout` ([`respond`]) and
//! `sidebar_band_heights` ([`band_heights`]).

use crate::sidebar_drag_geometry::Rect;
use crate::sidebar_layout::{Alignment, ArrangementLayout, Content, Item, Look, Section};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// The pinned section's id: its workspaces are rows whatever a stored document says.
pub const PINNED_SECTION: &str = "sec_pinned";
/// Home's section: no line under it.
pub const TOP_SECTION: &str = "sec_top";
/// The key of the line drawn above the first section.
pub const LEADING_SEPARATOR_KEY: &str = "leading";
/// A client-only item's id prefix (`LayoutItemID.transientPrefix`).
pub const TRANSIENT_PREFIX: &str = "client.";
/// An item ref kind that points at a workspace (`LayoutItemRef.workspaceKind`).
pub const WORKSPACE_KIND: &str = "workspace";

/// How pinned sections look (`SectionsLookVariant`, its Swift raw values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LookVariant {
    #[default]
    Quiet,
    Card,
    Tray,
    Lines,
    LinesIcons,
}

/// How icon-only sections tile in a look.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tiling {
    Grid,
    Buttons,
}

impl LookVariant {
    pub fn shows_headers(self) -> bool {
        matches!(self, LookVariant::Quiet | LookVariant::Card | LookVariant::Tray)
    }

    pub fn separates_sections(self) -> bool {
        matches!(self, LookVariant::Lines | LookVariant::LinesIcons)
    }

    /// The tiling `section` uses in this look, or none for rows.
    pub fn tiling(self, section: &Section) -> Option<Tiling> {
        if section.look != Look::BuiltIn {
            return None;
        }
        match self {
            LookVariant::Tray => Some(Tiling::Grid),
            LookVariant::LinesIcons => Some(Tiling::Buttons),
            LookVariant::Quiet | LookVariant::Card | LookVariant::Lines => None,
        }
    }
}

/// Sizes the region layout reads (`SidebarRegionMetrics`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Metrics {
    pub row_height: f64,
    pub header_height: f64,
    pub inset: f64,
    pub section_gap: f64,
    pub padding: f64,
    pub card_padding: f64,
    pub tile_min_width: f64,
    pub tile_height: f64,
    pub tile_gap: f64,
    /// Width of one icon button; none: the row height.
    #[serde(default)]
    pub icon_button_width: Option<f64>,
    #[serde(default = "one")]
    pub line_width: f64,
    /// Height of one large labeled tile; none: two rows and a tile gap.
    #[serde(default)]
    pub favorite_height: Option<f64>,
    #[serde(default)]
    pub glyph_column: Option<f64>,
    #[serde(default)]
    pub top_padding: Option<f64>,
    #[serde(default)]
    pub bottom_padding: Option<f64>,
    #[serde(default)]
    pub leading_separator: bool,
    #[serde(default)]
    pub trailing_trim: f64,
    #[serde(default)]
    pub row_gap: f64,
}

fn one() -> f64 {
    1.0
}

impl Metrics {
    pub fn icon_button_width(&self) -> f64 {
        self.icon_button_width.unwrap_or(self.row_height)
    }

    pub fn favorite_height(&self) -> f64 {
        self.favorite_height.unwrap_or(self.row_height * 2.0 + self.tile_gap)
    }
}

/// What one placed element draws (`SidebarRegionRow.Kind`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RowKind {
    Header { section: String },
    Item { item: String, section: String },
    /// An icon-only item: a grid tile or an inline icon button.
    Tile { item: String, section: String },
    /// An inline item with icon and label.
    Chip { item: String, section: String },
    /// The content of an app's section.
    App { section: String },
}

impl RowKind {
    pub fn section(&self) -> &str {
        match self {
            RowKind::Header { section }
            | RowKind::App { section }
            | RowKind::Item { section, .. }
            | RowKind::Tile { section, .. }
            | RowKind::Chip { section, .. } => section,
        }
    }

    pub fn item(&self) -> Option<&str> {
        match self {
            RowKind::Item { item, .. } | RowKind::Tile { item, .. } | RowKind::Chip { item, .. } => {
                Some(item)
            }
            RowKind::Header { .. } | RowKind::App { .. } => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Row {
    #[serde(flatten)]
    pub kind: RowKind,
    pub frame: Rect,
}

/// How a section's items flow (`SectionFlow.Mode`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Tiles in columns (none: as many as fit).
    Grid { columns: Option<i64> },
    /// Large labeled tiles in columns (none: as many as fit).
    Tiles { columns: Option<i64> },
    /// One line; labels while they fit unless `icons_only`.
    Inline { icons_only: bool },
}

/// One section's placed lines (`SectionFlow.Result`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Flow {
    pub rows: Vec<Row>,
    pub height: f64,
    pub lines: i64,
    pub line_height: f64,
    pub gap: f64,
    /// The line gap a placement chose itself (an icon line has none).
    pub fixed_gap: Option<f64>,
}

/// The sizes a flow reads besides the metrics.
#[derive(Debug, Clone, Copy)]
pub struct Widths<'a> {
    /// Each item's icon + label width (inline); a missing entry means icon only.
    pub labels: &'a HashMap<String, f64>,
    /// An icon-only item wider than a square on an icon line.
    pub icons: &'a HashMap<String, f64>,
}

fn align_of(section: &Section) -> Alignment {
    match &section.arrangement.align {
        // The app decodes an unknown alignment as leading.
        Alignment::Other(_) => Alignment::Leading,
        align => align.clone(),
    }
}

fn gap_of(section: &Section) -> Option<f64> {
    section.arrangement.gap.map(|gap| gap as f64)
}

/// `Int(value)` without Swift's trap on a value out of range.
fn int(value: f64) -> i64 {
    value as i64
}

/// The mode `section` uses in `look`, or none for rows (always none for the pinned section).
pub fn mode(section: &Section, look: LookVariant) -> Option<Mode> {
    if section.id == PINNED_SECTION {
        return None;
    }
    match section.arrangement.layout {
        ArrangementLayout::Inline => return Some(Mode::Inline { icons_only: false }),
        ArrangementLayout::Grid => return Some(Mode::Grid { columns: section.arrangement.columns }),
        ArrangementLayout::Tiles => return Some(Mode::Tiles { columns: section.arrangement.columns }),
        ArrangementLayout::List | ArrangementLayout::Other(_) => {}
    }
    match look.tiling(section) {
        Some(Tiling::Grid) => Some(Mode::Grid { columns: None }),
        Some(Tiling::Buttons) => Some(Mode::Inline { icons_only: true }),
        None => None,
    }
}

/// Places `section`'s items on lines from `(x, y)`, `width` wide (`SectionFlow.place`).
pub fn place(
    section: &Section,
    mode: Mode,
    origin: (f64, f64),
    width: f64,
    widths: Widths<'_>,
    m: &Metrics,
) -> Flow {
    if section.items.is_empty() {
        return Flow::default();
    }
    let mut flow = place_lines(section, mode, origin, width, widths, m);
    flow.gap = flow.fixed_gap.or_else(|| gap_of(section)).unwrap_or(m.tile_gap);
    flow
}

fn place_lines(
    section: &Section,
    mode: Mode,
    origin: (f64, f64),
    width: f64,
    widths: Widths<'_>,
    m: &Metrics,
) -> Flow {
    let items = &section.items;
    let gap = gap_of(section).unwrap_or(m.tile_gap);
    let align = align_of(section);
    let tile = |item: &Item| RowKind::Tile { item: item.id.clone(), section: section.id.clone() };
    match mode {
        Mode::Grid { columns } => {
            if let Some(columns) = columns
                && items.iter().any(|i| i.span.is_some())
            {
                return place_spans(section, columns, origin, width, gap, widths.labels, m);
            }
            let lines = Lines { gap, align, line_height: m.tile_height, full_line: None };
            place_columns(section, columns, origin, width, lines, m)
        }
        Mode::Tiles { columns } => {
            // Labeled tiles always fill the line, so a short last line keeps the column width of the lines above it.
            let lines = Lines { gap, align: Alignment::Fill, line_height: m.favorite_height(), full_line: None };
            place_columns(section, columns, origin, width, lines, m)
        }
        Mode::Inline { icons_only } => {
            if let Some(column) = m.glyph_column
                && (icons_only || items.iter().all(|i| !widths.labels.contains_key(&i.id)))
            {
                return place_icon_line(section, column, origin, width, widths.icons, m);
            }
            let icon = m.icon_button_width();
            let chip = |item: &Item| widths.labels.get(&item.id).copied().unwrap_or(icon);
            let chip_total: f64 =
                items.iter().map(chip).sum::<f64>() + gap * (items.len() as f64 - 1.0);
            let lines = Lines { gap, align, line_height: m.row_height, full_line: None };
            if !icons_only && chip_total <= width {
                let kind = |item: &Item| {
                    if widths.labels.contains_key(&item.id) {
                        RowKind::Chip { item: item.id.clone(), section: section.id.clone() }
                    } else {
                        tile(item)
                    }
                };
                let all: Vec<&Item> = items.iter().collect();
                return lay(&[all], &kind, &chip, origin, width, lines);
            }
            let per_line = 1.max(int((width + gap) / (icon + gap)));
            lay(&chunk(items, per_line), &tile, &|_| icon, origin, width, lines)
        }
    }
}

/// A line of icon-only items: row-height squares, no gap unless the section
/// sets one, wrapped when they do not fit. Leading lines put the first glyph
/// on the rows' glyph column.
fn place_icon_line(
    section: &Section,
    column: f64,
    (x, y): (f64, f64),
    width: f64,
    icon_widths: &HashMap<String, f64>,
    m: &Metrics,
) -> Flow {
    let side = m.row_height;
    let gap = gap_of(section).unwrap_or(0.0);
    let align = align_of(section);
    let shift = if align == Alignment::Leading { 0f64.max(column - side / 2.0) } else { 0.0 };
    let icon = |item: &Item| icon_widths.get(&item.id).copied().unwrap_or(side);
    let widest = section.items.iter().map(icon).fold(None, |widest: Option<f64>, w| {
        Some(widest.map_or(w, |v| v.max(w)))
    });
    let widest = widest.unwrap_or(side);
    let per_line = 1.max(int((width - shift + gap) / (widest + gap)));
    let tile = |item: &Item| RowKind::Tile { item: item.id.clone(), section: section.id.clone() };
    let lines = Lines { gap, align, line_height: side, full_line: None };
    let mut flow =
        lay(&chunk(&section.items, per_line), &tile, &icon, (x + shift, y), 0f64.max(width - shift), lines);
    flow.fixed_gap = Some(gap);
    flow
}

/// Equal tiles in `columns` (none: as many as fit at the minimum tile width).
/// Fitted columns (or fill) stretch the tiles to the width; fixed columns
/// keep the tile size and place every line by the leftover of a full line,
/// so columns line up.
fn place_columns(
    section: &Section,
    columns: Option<i64>,
    origin: (f64, f64),
    width: f64,
    lines: Lines,
    m: &Metrics,
) -> Flow {
    let gap = lines.gap;
    let fit = 1.max(int((width + gap) / (m.tile_min_width + gap)));
    let count = columns.unwrap_or(fit).max(1).min(fit);
    let stretched = lines.align == Alignment::Fill || columns.is_none();
    let tile_width =
        if stretched { (width - (count - 1) as f64 * gap) / count as f64 } else { m.tile_min_width };
    let tile = |item: &Item| RowKind::Tile { item: item.id.clone(), section: section.id.clone() };
    let lines = Lines {
        align: if stretched { Alignment::Leading } else { lines.align },
        full_line: Some(count as f64 * (tile_width + gap) - gap),
        ..lines
    };
    lay(&chunk(&section.items, count), &tile, &|_| tile_width, origin, width, lines)
}

/// A grid with spans: lines of `columns` equal columns; an item takes `span`
/// of them (one when none) and moves to the next line when it does not fit.
/// A labeled item draws icon and label, others icon only; lines are row
/// height. On a line with a labeled item, an icon-only item is a row-height
/// square and the labeled items take up the difference.
fn place_spans(
    section: &Section,
    columns: i64,
    (x, y): (f64, f64),
    width: f64,
    gap: f64,
    label_widths: &HashMap<String, f64>,
    m: &Metrics,
) -> Flow {
    let unit = 0f64.max((width - (columns - 1) as f64 * gap) / columns as f64);
    let mut line_items: Vec<Vec<(&Item, i64)>> = Vec::new();
    let mut column = 0i64;
    for item in &section.items {
        let span = item.span.unwrap_or(1).max(1).min(columns);
        if line_items.is_empty() || column.saturating_add(span) > columns {
            line_items.push(Vec::new());
            column = 0;
        }
        if let Some(line) = line_items.last_mut() {
            line.push((item, span));
        }
        column = column.saturating_add(span);
    }
    let mut rows = Vec::new();
    for (line, items) in line_items.iter().enumerate() {
        let labeled: Vec<bool> =
            items.iter().map(|(item, _)| item.shows_label && label_widths.contains_key(&item.id)).collect();
        let mut widths: Vec<f64> =
            items.iter().map(|(_, span)| *span as f64 * unit + (*span - 1) as f64 * gap).collect();
        if labeled.contains(&true) {
            let mut grown = 0.0;
            for (w, _) in widths.iter_mut().zip(&labeled).filter(|(_, l)| !**l) {
                grown += m.row_height - *w;
                *w = m.row_height;
            }
            let labeled_spans: f64 =
                items.iter().zip(&labeled).filter(|(_, l)| **l).map(|((_, span), _)| *span as f64).sum();
            for ((w, _), (_, span)) in widths.iter_mut().zip(&labeled).zip(items).filter(|((_, l), _)| **l) {
                *w = 0f64.max(*w - grown * *span as f64 / labeled_spans);
            }
        }
        let mut item_x = x;
        for (((item, _), w), labeled) in items.iter().zip(&widths).zip(&labeled) {
            let (item, section) = (item.id.clone(), section.id.clone());
            let kind = if *labeled { RowKind::Chip { item, section } } else { RowKind::Tile { item, section } };
            let frame = Rect {
                x: item_x,
                y: y + line as f64 * (m.row_height + gap),
                width: *w,
                height: m.row_height,
            };
            rows.push(Row { kind, frame });
            item_x += w + gap;
        }
    }
    let lines = line_items.len() as i64;
    let height = lines as f64 * m.row_height + (lines - 1).max(0) as f64 * gap;
    Flow { rows, height, lines, line_height: m.row_height, gap: 0.0, fixed_gap: None }
}

fn chunk(items: &[Item], size: i64) -> Vec<Vec<&Item>> {
    let size = usize::try_from(size.max(1)).unwrap_or(usize::MAX);
    items.chunks(size).map(|line| line.iter().collect()).collect()
}

/// How `lay` places its lines.
#[derive(Debug, Clone)]
struct Lines {
    gap: f64,
    align: Alignment,
    line_height: f64,
    full_line: Option<f64>,
}

fn lay(
    lines: &[Vec<&Item>],
    kind: &dyn Fn(&Item) -> RowKind,
    widths: &dyn Fn(&Item) -> f64,
    (x, y): (f64, f64),
    width: f64,
    spec: Lines,
) -> Flow {
    let Lines { gap, align, line_height, full_line } = spec;
    let mut rows = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        let w: Vec<f64> = line.iter().map(|item| widths(item)).collect();
        let used = full_line.unwrap_or_else(|| {
            w.iter().sum::<f64>() + gap * (line.len() as f64 - 1.0).max(0.0)
        });
        let leftover = 0f64.max(width - used);
        let mut spacing = gap;
        // Where fill puts all of the leftover, between labeled chips and the icon-only tiles after them.
        let mut split = None;
        let mut cursor = match align {
            Alignment::Center => x + leftover / 2.0,
            Alignment::Trailing => x + leftover,
            Alignment::Fill => {
                // Labeled items stay leading and icon-only items after them group at the trailing edge;
                // otherwise two or more spread to both edges and one stays leading.
                let tiles: Vec<bool> =
                    line.iter().map(|item| matches!(kind(item), RowKind::Tile { .. })).collect();
                match tiles.iter().position(|t| *t) {
                    Some(first) if first > 0 && tiles.get(first..).is_some_and(|rest| !rest.contains(&false)) => {
                        split = Some(first);
                    }
                    _ if line.len() > 1 => spacing = gap + leftover / (line.len() - 1) as f64,
                    _ => {}
                }
                x
            }
            Alignment::Leading | Alignment::Other(_) => x,
        };
        let line_y = y + index as f64 * (line_height + gap);
        for (position, (item, item_width)) in line.iter().zip(&w).enumerate() {
            if Some(position) == split {
                cursor += leftover;
            }
            rows.push(Row {
                kind: kind(item),
                frame: Rect { x: cursor, y: line_y, width: *item_width, height: line_height },
            });
            cursor += item_width + spacing;
        }
    }
    let count = lines.len() as i64;
    let height = count as f64 * line_height + (count - 1).max(0) as f64 * gap;
    Flow { rows, height, lines: count, line_height, gap: 0.0, fixed_gap: None }
}

/// Frames of a pinned region's sections (`SidebarRegionLayout`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct RegionLayout {
    pub rows: Vec<Row>,
    /// Card backgrounds (card look, and tiles sections), one per carded section.
    pub cards: Vec<Rect>,
    /// Indices into `cards` of tiles sections, ascending.
    pub tiled_cards: Vec<usize>,
    /// The section of each card, in `cards` order.
    pub card_sections: Vec<String>,
    /// Lines between sections (lines looks).
    pub separators: Vec<Rect>,
    /// The key of each line: the section below it ([`LEADING_SEPARATOR_KEY`] for the first line).
    pub separator_keys: Vec<String>,
    /// Each shown section's full-width frame, in order.
    pub section_frames: Vec<Rect>,
    pub section_ids: Vec<String>,
    pub height: f64,
    /// Height of the first `max_rows` rows of each section, summed.
    pub capped_height: f64,
}

impl RegionLayout {
    /// The first row whose frame holds the point (`row(at:)`).
    pub fn row_at(&self, x: f64, y: f64) -> Option<&Row> {
        self.rows.iter().find(|row| contains(&row.frame, x, y))
    }

    /// The height a pinned region takes: its content, capped by the
    /// sections' `max_rows` and by `share` of the sidebar's `available` height.
    pub fn pinned_height(&self, available: f64, share: f64) -> f64 {
        self.capped_height.min(0f64.max(available * share))
    }
}

/// `CGRect.contains`: the min edges in, the max edges out.
fn contains(frame: &Rect, x: f64, y: f64) -> bool {
    frame.width != 0.0
        && frame.height != 0.0
        && x >= frame.min_x()
        && x < frame.min_x() + frame.width.abs()
        && y >= frame.min_y()
        && y < frame.max_y()
}

/// The header title a section draws (`headerTitle`).
pub fn header_title(section: &Section) -> Option<&str> {
    if section.shows_title { section.title.as_deref() } else { None }
}

/// An empty titled section's title: it draws it in every look.
pub fn empty_title(section: &Section) -> Option<&str> {
    if section.content == Content::Items && section.items.is_empty() { header_title(section) } else { None }
}

/// The header a section draws in `look`, or none.
pub fn header(section: &Section, look: LookVariant) -> Option<&str> {
    if look.shows_headers() { header_title(section) } else { None }
}

/// A tiles section sits on its own card in every look, and every section does in the card look.
pub fn is_carded(section: &Section, look: LookVariant) -> bool {
    look == LookVariant::Card || matches!(mode(section, look), Some(Mode::Tiles { .. }))
}

/// How far a section's list rows end short of its header's right edge.
pub fn item_trailing_trim(section: &Section, look: LookVariant, m: &Metrics) -> f64 {
    if is_carded(section, look) { 0.0 } else { m.trailing_trim }
}

/// What a band lays out and the sizes it reads.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Band {
    #[serde(default)]
    pub sections: Vec<Section>,
    pub width: f64,
    #[serde(default)]
    pub look: LookVariant,
    #[serde(default)]
    pub collapsed: Vec<String>,
    pub metrics: Metrics,
    #[serde(default)]
    pub label_widths: HashMap<String, f64>,
    #[serde(default)]
    pub app_heights: HashMap<String, f64>,
    #[serde(default)]
    pub icon_widths: HashMap<String, f64>,
}

/// `SidebarRegionLayout.make`.
pub fn make(band: &Band) -> RegionLayout {
    let m = &band.metrics;
    let look = band.look;
    let collapsed: HashSet<&str> = band.collapsed.iter().map(String::as_str).collect();
    let widths = Widths { labels: &band.label_widths, icons: &band.icon_widths };
    // An app section shows only with content (a height from its provider).
    let shown: Vec<&Section> = band
        .sections
        .iter()
        .filter(|section| match section.content {
            Content::Items => {
                !section.items.is_empty() || header(section, look).is_some() || empty_title(section).is_some()
            }
            Content::App => band.app_heights.get(&section.id).copied().unwrap_or(0.0) > 0.0,
            Content::Workspaces | Content::Other(_) => false,
        })
        .collect();
    if shown.is_empty() {
        return RegionLayout::default();
    }
    let width = band.width;
    let mut result = RegionLayout::default();
    let mut tiled_cards = Vec::new();
    let mut y = m.top_padding.unwrap_or(m.padding);
    let mut capped = y;
    if m.leading_separator && look.separates_sections() {
        result.separators.push(Rect { x: 0.0, y: (y - m.line_width) / 2.0, width, height: m.line_width });
        result.separator_keys.push(LEADING_SEPARATOR_KEY.to_owned());
    }
    for (index, section) in shown.iter().enumerate() {
        if index > 0 {
            // No line under Home's section; its gap stays.
            if look.separates_sections() && shown.get(index - 1).is_some_and(|p| p.id != TOP_SECTION) {
                result.separators.push(Rect {
                    x: 0.0,
                    y: y + (m.section_gap - m.line_width) / 2.0,
                    width,
                    height: m.line_width,
                });
                result.separator_keys.push(section.id.clone());
            }
            y += m.section_gap;
            capped += m.section_gap;
        }
        let flow_mode = mode(section, look);
        let tiled = matches!(flow_mode, Some(Mode::Tiles { .. }));
        let carded = is_carded(section, look);
        let x = if carded { m.inset } else { 0.0 };
        let inner_width = 0f64.max(width - x * 2.0);
        let top = y;
        if carded {
            y += m.card_padding;
        }
        let mut section_capped = if carded { m.card_padding * 2.0 } else { 0.0 };
        let title = header(section, look).or_else(|| empty_title(section));
        if title.is_some() {
            result.rows.push(Row {
                kind: RowKind::Header { section: section.id.clone() },
                frame: Rect { x, y, width: inner_width, height: m.header_height },
            });
            y += m.header_height;
            section_capped += m.header_height;
        }
        if !(title.is_some() && collapsed.contains(section.id.as_str())) {
            let app_height =
                if section.content == Content::App { band.app_heights.get(&section.id).copied() } else { None };
            if let Some(height) = app_height {
                result.rows.push(Row {
                    kind: RowKind::App { section: section.id.clone() },
                    frame: Rect { x, y, width: inner_width, height },
                });
                y += height;
                section_capped += height;
            } else if let Some(flow_mode) = flow_mode {
                let flow_inset = if tiled { m.card_padding } else { m.inset };
                let flow = place(
                    section,
                    flow_mode,
                    (x + flow_inset, y),
                    0f64.max(inner_width - flow_inset * 2.0),
                    widths,
                    m,
                );
                y += flow.height;
                let lines = flow.lines.min(section.max_rows.unwrap_or(flow.lines));
                section_capped += lines as f64 * flow.line_height + (lines - 1).max(0) as f64 * flow.gap;
                result.rows.extend(flow.rows);
            } else {
                let trim = item_trailing_trim(section, look, m);
                for (index, item) in section.items.iter().enumerate() {
                    if index > 0 {
                        y += m.row_gap;
                    }
                    result.rows.push(Row {
                        kind: RowKind::Item { item: item.id.clone(), section: section.id.clone() },
                        frame: Rect { x, y, width: 0f64.max(inner_width - trim), height: m.row_height },
                    });
                    y += m.row_height;
                }
                let count = section.items.len() as i64;
                let lines = count.min(section.max_rows.unwrap_or(count));
                section_capped += lines as f64 * m.row_height + (lines - 1).max(0) as f64 * m.row_gap;
            }
        }
        if carded {
            y += m.card_padding;
            if tiled {
                tiled_cards.push(result.cards.len());
            }
            result.cards.push(Rect { x, y: top, width: inner_width, height: y - top });
            result.card_sections.push(section.id.clone());
        }
        result.section_frames.push(Rect { x: 0.0, y: top, width, height: y - top });
        result.section_ids.push(section.id.clone());
        capped += section_capped;
        if tiled {
            y += m.section_gap;
            capped += m.section_gap;
        }
    }
    y += m.bottom_padding.unwrap_or(m.padding);
    capped += m.bottom_padding.unwrap_or(m.padding);
    result.height = y;
    result.capped_height = capped.min(y);
    result.tiled_cards = tiled_cards;
    result
}

/// Where a workspace row dragged from the list lands in the band above it (`SidebarRegionDrop`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Drop {
    pub section: String,
    pub index: i64,
    /// The section's frame in the band (the outline the drag shows).
    pub frame: Rect,
}

fn union(a: Rect, b: &Rect) -> Rect {
    let (x0, y0) = (a.min_x().min(b.min_x()), a.min_y().min(b.min_y()));
    let x1 = (a.min_x() + a.width.abs()).max(b.min_x() + b.width.abs());
    let (y1, _) = (a.max_y().max(b.max_y()), ());
    Rect { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }
}

/// Whether `(x, y)` is past `row` in reading order: below a list row's
/// middle, or beside or below a tile or chip on its line.
fn is_past(x: f64, y: f64, row: &Row) -> bool {
    let frame = &row.frame;
    match row.kind {
        RowKind::Tile { .. } | RowKind::Chip { .. } => {
            if y >= frame.max_y() {
                return true;
            }
            y >= frame.min_y() && x >= frame.mid_x()
        }
        _ => y >= frame.mid_y(),
    }
}

/// The drop under `(x, y)` (band coordinates), or none when the point is
/// over no items section of `sections`. The items section under the point
/// (its rows and half a `gap` around them) takes it, at the index of the
/// first item the point is not past (never before the section's leading
/// built-in rows); past every item, it goes last.
pub fn drop_target(x: f64, y: f64, layout: &RegionLayout, sections: &[Section], gap: f64) -> Option<Drop> {
    for section in sections.iter().filter(|s| s.content == Content::Items) {
        let rows: Vec<&Row> = layout.rows.iter().filter(|row| row.kind.section() == section.id).collect();
        let Some((first, rest)) = rows.split_first() else { continue };
        let union = rest.iter().fold(first.frame, |frame, row| union(frame, &row.frame));
        let frame = Rect { y: union.y - gap / 2.0, height: union.height + gap, ..union };
        if !(y >= frame.min_y() && y < frame.max_y()) {
            continue;
        }
        // A client item drawn in the section is no document item: the drop maps past it.
        let next = rows.iter().find(|row| {
            row.kind.item().is_some_and(|id| !id.starts_with(TRANSIENT_PREFIX)) && !is_past(x, y, row)
        });
        let index = next
            .and_then(|row| row.kind.item())
            .and_then(|id| section.items.iter().position(|item| item.id == id))
            .unwrap_or(section.items.len());
        // The built-in rows (Home, App Store) stay at the top of their section: a pin goes after them.
        let built_ins = section.items.iter().take_while(|item| item.reference.kind != WORKSPACE_KIND).count();
        let index = i64::try_from(index.max(built_ins)).unwrap_or(i64::MAX);
        return Some(Drop { section: section.id.clone(), index, frame });
    }
    None
}

/// A drop-to-pin question.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct DropAt {
    pub x: f64,
    pub y: f64,
    pub gap: f64,
}

/// A pinned-height question.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct PinnedAt {
    pub available: f64,
    pub share: f64,
}

/// Op `sidebar_region_layout`: a band, and optionally a drop and a pinned height over its layout.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    #[serde(flatten)]
    pub band: Band,
    #[serde(default)]
    pub drop: Vec<DropAt>,
    #[serde(default)]
    pub pinned: Option<PinnedAt>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Reply {
    pub layout: RegionLayout,
    /// One answer per `drop` question, in order.
    pub drops: Vec<Option<Drop>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pinned_height: Option<f64>,
}

pub fn respond(request: &Request) -> Reply {
    let layout = make(&request.band);
    let drops = request
        .drop
        .iter()
        .map(|at| drop_target(at.x, at.y, &layout, &request.band.sections, at.gap))
        .collect();
    let pinned_height = request.pinned.map(|p| layout.pinned_height(p.available, p.share));
    Reply { layout, drops, pinned_height }
}

/// Op `sidebar_band_heights` (`SidebarBandHeights.resolve`): the two bands'
/// capped heights and the sidebar's room.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct BandHeights {
    pub above_capped: f64,
    pub below_capped: f64,
    pub available: f64,
    #[serde(default)]
    pub pinned_bands_scroll: bool,
    #[serde(default)]
    pub top_band_max_share: f64,
    #[serde(default)]
    pub bottom_band_max_share: f64,
    #[serde(default)]
    pub minimum_list: f64,
    #[serde(default)]
    pub band_floor: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Heights {
    pub above: f64,
    pub below: f64,
}

/// Heights of the bands above and below the list: with scrolling on each
/// band stops at its share; either way the two leave the list `minimum_list`
/// (they shrink in proportion), but each keeps at least `band_floor` of its content.
pub fn band_heights(p: &BandHeights) -> Heights {
    let (mut a, mut b) = (p.above_capped, p.below_capped);
    if p.pinned_bands_scroll {
        a = p.above_capped.min(0f64.max(p.available * p.top_band_max_share));
        b = p.below_capped.min(0f64.max(p.available * p.bottom_band_max_share));
    }
    let room = 0f64.max(p.available - p.minimum_list);
    if a + b > room && a + b > 0.0 {
        let scale = room / (a + b);
        a = (a * scale).floor();
        b = (b * scale).floor();
    }
    Heights { above: a.max(p.above_capped.min(p.band_floor)), below: b.max(p.below_capped.min(p.band_floor)) }
}

#[cfg(test)]
#[path = "sidebar_region_layout_tests.rs"]
mod tests;
