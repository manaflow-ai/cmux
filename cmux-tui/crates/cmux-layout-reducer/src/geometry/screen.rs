//! All frames of one screen (Swift `ScreenGeometry` and its `+ScrollAreas`, `+Canvas` extensions), the
//! layout model prototypes that reinterpret a columns screen (`LayoutModelPrototype`), a column's
//! minimum size (`LayoutColumn.minimumSize`), floating panes' cards (`LayoutFloatingPane`) and whether a
//! split fits before it is sent (`SplitRoom`).
//!
//! Content space has a top-left origin; in columns mode x runs over the whole scrollable strip from the
//! strip's own origin `strip_min_x`. Docked columns, their panes and dividers are in view coordinates
//! and never scroll (`fixed_panes`, `fixed_splits`, `dock`).

use super::column_strip;
use super::divider_band::DividerBand;
use super::dock_strip::{self, Dock, DockFrame, DockMode, Docks, FrameOrientation};
use super::pane_chrome::ChromeStyle;
use super::row_stack::{Row, RowEdge, RowStack};
use super::split_layout::{self, DividerGeometry, SplitLayout, SplitNode, SplitStyle};
use super::{DockEdge, Point, Rect, Size, SplitAxis, round_to_pixel, swift_max, swift_min};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// `DockRole`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockRole {
    /// The agent chat column: new terminals and browsers open beside it, never in it.
    AgentChat,
}

fn right() -> DockEdge {
    DockEdge::Right
}

fn docked() -> DockMode {
    DockMode::Docked
}

/// `DockColumn`: the edge a column is pinned to and how it shares the viewport (the pin and tab flags
/// play no part in geometry).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockColumn {
    #[serde(default = "right")]
    pub edge: DockEdge,
    #[serde(default = "docked")]
    pub mode: DockMode,
    #[serde(default)]
    pub role: Option<DockRole>,
}

/// `LayoutRow`: a row's id, permille height and split tree.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LayoutRow {
    pub id: String,
    pub height: i64,
    pub root: SplitNode,
}

/// `LayoutColumn`: a column's width fraction, its tree (with rows, the daemon's compat chain), its dock
/// and its rows (empty or one: the column's own tree).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Column {
    pub id: String,
    pub width: f64,
    pub root: SplitNode,
    #[serde(default)]
    pub dock: Option<DockColumn>,
    #[serde(default)]
    pub rows: Vec<LayoutRow>,
}

impl Column {
    /// `hasRows`: two or more rows.
    pub fn has_rows(&self) -> bool {
        self.rows.len() > 1
    }

    /// `row(containing:)`.
    pub fn row_containing(&self, pane: &str) -> Option<&LayoutRow> {
        self.rows.iter().find(|row| row.root.contains(pane))
    }

    /// `trees`: the rows' trees with two or more rows, else the column's own.
    pub fn trees(&self) -> Vec<&SplitNode> {
        if self.has_rows() {
            self.rows.iter().map(|row| &row.root).collect()
        } else {
            vec![&self.root]
        }
    }

    /// `tree(containing:)`: the tree holding `pane`, its row's or the column's own.
    pub fn tree_containing(&self, pane: &str) -> Option<&SplitNode> {
        self.trees().into_iter().find(|tree| tree.contains(pane))
    }

    /// `settingRatio(_:for:)`: `split`'s ratio replaced in the tree and in every row.
    #[must_use]
    pub fn setting_ratio(&self, ratio: f64, split: &str) -> Column {
        let mut column = self.clone();
        column.root = self.root.setting_ratio(ratio, split);
        for row in &mut column.rows {
            row.root = row.root.setting_ratio(ratio, split);
        }
        column
    }

    /// `minimumSize(style:)`: the panes' minimum, one pane wide with scroll areas on, widened for a
    /// docked agent chat.
    pub fn minimum_size(&self, style: &ScreenStyle) -> Size {
        let mut size = split_layout::minimum_size(&self.root, &style.split());
        if style.scroll_areas_enabled {
            size.width = swift_min(size.width, style.split().minimum_pane_size().width);
        }
        if self.dock.and_then(|dock| dock.role) == Some(DockRole::AgentChat) {
            size.width = swift_max(
                size.width,
                style.minimum_agent_chat_content_width + style.pane_padding * 2.,
            );
        }
        size
    }
}

/// `ScreenLayout`: `{"splits": tree}` or `{"columns": [column]}`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenLayout {
    Splits(SplitNode),
    Columns(Vec<Column>),
}

impl ScreenLayout {
    /// `column(containing:)`: the first column whose tree holds `pane`; none for a splits screen.
    pub fn column_containing(&self, pane: &str) -> Option<&Column> {
        match self {
            ScreenLayout::Splits(_) => None,
            ScreenLayout::Columns(columns) => {
                columns.iter().find(|column| column.root.contains(pane))
            }
        }
    }

    /// `settingRatio(_:for:)`.
    #[must_use]
    pub fn setting_ratio(&self, ratio: f64, split: &str) -> ScreenLayout {
        match self {
            ScreenLayout::Splits(root) => ScreenLayout::Splits(root.setting_ratio(ratio, split)),
            ScreenLayout::Columns(columns) => ScreenLayout::Columns(
                columns.iter().map(|column| column.setting_ratio(ratio, split)).collect(),
            ),
        }
    }

    /// `settingWidth(_:for:)`: `column`'s width share replaced; a splits screen is unchanged.
    #[must_use]
    pub fn setting_width(&self, width: f64, column: &str) -> ScreenLayout {
        match self {
            ScreenLayout::Splits(_) => self.clone(),
            ScreenLayout::Columns(columns) => ScreenLayout::Columns(
                columns
                    .iter()
                    .map(|entry| {
                        let mut entry = entry.clone();
                        if entry.id == column {
                            entry.width = width;
                        }
                        entry
                    })
                    .collect(),
            ),
        }
    }
}

/// `LayoutPrototypeModel`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PrototypeModel {
    #[default]
    Off,
    FrameDocks,
    Grid,
}

/// `LayoutPrototypeDockEdge`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PrototypeDockEdge {
    #[default]
    Bottom,
    Top,
}

/// `LayoutPrototypeSettings`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PrototypeSettings {
    pub model: PrototypeModel,
    pub dock_edge: PrototypeDockEdge,
    pub orientation: FrameOrientation,
    pub dock_mode: DockMode,
}

impl Default for PrototypeSettings {
    fn default() -> Self {
        Self {
            model: PrototypeModel::Off,
            dock_edge: PrototypeDockEdge::Bottom,
            orientation: FrameOrientation::ColumnMajor,
            dock_mode: DockMode::Docked,
        }
    }
}

/// The `LayoutStyle` values screen geometry reads.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ScreenStyle {
    pub divider_thickness: f64,
    pub divider_hit_thickness: f64,
    pub pane_padding: f64,
    pub pane_chrome_height: f64,
    pub minimum_pane_content_size: Size,
    pub column_gap: f64,
    pub pane_corner_radius: f64,
    pub minimum_agent_chat_content_width: f64,
    pub new_column_drop_width: f64,
    pub frame_orientation: FrameOrientation,
    pub rows_enabled: bool,
    pub scroll_areas_enabled: bool,
    pub prototype: PrototypeSettings,
}

impl Default for ScreenStyle {
    fn default() -> Self {
        let split = SplitStyle::default();
        let chrome = ChromeStyle::default();
        Self {
            divider_thickness: split.divider_thickness,
            divider_hit_thickness: split.divider_hit_thickness,
            pane_padding: split.pane_padding,
            pane_chrome_height: split.pane_chrome_height,
            minimum_pane_content_size: split.minimum_pane_content_size,
            column_gap: chrome.column_gap,
            pane_corner_radius: chrome.pane_corner_radius,
            minimum_agent_chat_content_width: 381.,
            new_column_drop_width: 36.,
            frame_orientation: FrameOrientation::ColumnMajor,
            rows_enabled: true,
            scroll_areas_enabled: false,
            prototype: PrototypeSettings::default(),
        }
    }
}

impl ScreenStyle {
    /// The values split geometry reads.
    pub fn split(&self) -> SplitStyle {
        SplitStyle {
            divider_thickness: self.divider_thickness,
            divider_hit_thickness: self.divider_hit_thickness,
            pane_padding: self.pane_padding,
            pane_chrome_height: self.pane_chrome_height,
            minimum_pane_content_size: self.minimum_pane_content_size,
        }
    }

    /// The values the pane chrome metrics read.
    pub fn chrome(&self) -> ChromeStyle {
        ChromeStyle {
            pane_padding: self.pane_padding,
            column_gap: self.column_gap,
            divider_thickness: self.divider_thickness,
            divider_hit_thickness: self.divider_hit_thickness,
            pane_corner_radius: self.pane_corner_radius,
        }
    }
}

/// `ColumnEdgeGeometry`: the resize handle on a column's trailing edge, or on a docked column's inner
/// edge.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnEdge {
    pub column: String,
    pub column_frame: Rect,
    pub hit_frame: Rect,
    pub dock_edge: Option<DockEdge>,
    pub axis: SplitAxis,
}

/// `ColumnGapZone`: a "new column" drop zone centered on a column gap; `after: None` is before the
/// first column.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct GapZone {
    pub after: Option<String>,
    pub frame: Rect,
}

/// `ScrollAreaGeometry.Cell`: one cell of a scroll area's horizontal chain; `frame: None` is
/// `CGRect.null` (no pane laid out).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrollCell {
    pub panes: Vec<String>,
    pub frame: Option<Rect>,
    pub pane_frames: BTreeMap<String, Rect>,
}

/// `ScrollAreaGeometry`: a tree laid out at its minimum width and shown through `window`.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrollArea {
    pub id: String,
    pub window: Rect,
    pub content_width: f64,
    pub panes: Vec<String>,
    pub cells: Vec<ScrollCell>,
    pub splits: Vec<String>,
}

/// `LayoutFloatingPane`: a pane above the tiled layout, its frame in fractions of the pane area.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FloatingPane {
    pub pane: String,
    pub frame: Rect,
}

/// `LayoutFloatingPane.barHeight` and `rimWidth`.
pub const FLOATING_BAR_HEIGHT: f64 = 14.;
pub const FLOATING_RIM_WIDTH: f64 = 5.;

impl FloatingPane {
    /// `rect(in:scale:)`: the frame in a pane area of `size`, each edge on the pixel grid of `scale`.
    pub fn rect(&self, size: Size, scale: f64) -> Rect {
        let snap = |value: f64| if scale > 0. { (value * scale).round() / scale } else { value };
        let min_x = snap(self.frame.min_x() * size.width);
        let min_y = snap(self.frame.min_y() * size.height);
        let max_x = snap(self.frame.max_x() * size.width);
        let max_y = snap(self.frame.max_y() * size.height);
        Rect::new(min_x, min_y, swift_max(0., max_x - min_x), swift_max(0., max_y - min_y))
    }
}

/// `LayoutFloatingPane.paneRect(inCard:)`: the pane below the card's bar and inside its rim.
pub fn floating_pane_rect(card: Rect) -> Rect {
    Rect::new(
        card.min_x() + FLOATING_RIM_WIDTH,
        card.min_y() + FLOATING_BAR_HEIGHT,
        swift_max(0., card.width() - FLOATING_RIM_WIDTH * 2.),
        swift_max(0., card.height() - FLOATING_BAR_HEIGHT - FLOATING_RIM_WIDTH),
    )
}

/// `CGRect.union(_:)` onto `CGRect.null` (`None`).
fn union(acc: Option<Rect>, rect: Rect) -> Rect {
    match acc {
        None => Rect::new(rect.min_x(), rect.min_y(), rect.width(), rect.height()),
        Some(acc) => {
            let min_x = swift_min(acc.min_x(), rect.min_x());
            let min_y = swift_min(acc.min_y(), rect.min_y());
            let max_x = swift_max(acc.max_x(), rect.max_x());
            let max_y = swift_max(acc.max_y(), rect.max_y());
            Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
        }
    }
}

/// `ScreenGeometry`.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenGeometry {
    pub viewport: Size,
    pub panes: BTreeMap<String, Rect>,
    pub dividers: Vec<DividerGeometry>,
    pub columns: BTreeMap<String, Rect>,
    pub column_order: Vec<String>,
    pub column_edges: Vec<ColumnEdge>,
    pub gap_zones: Vec<GapZone>,
    pub content_width: f64,
    pub snap_offsets: Vec<f64>,
    pub is_columns: bool,
    pub strip_min_x: f64,
    pub strip_width: f64,
    pub strip_min_y: f64,
    pub strip_height: f64,
    pub uncovered_min_x: f64,
    pub uncovered_max_x: f64,
    pub uncovered_min_y: f64,
    pub uncovered_max_y: f64,
    pub clip_min_x: f64,
    pub clip_max_x: f64,
    pub clip_min_y: f64,
    pub clip_max_y: f64,
    pub dock: Vec<DockFrame>,
    pub fixed_panes: BTreeSet<String>,
    pub frame_orientation: FrameOrientation,
    pub fixed_splits: BTreeSet<String>,
    pub row_stacks: BTreeMap<String, RowStack>,
    pub row_edges: Vec<RowEdge>,
    pub row_column_of_pane: BTreeMap<String, String>,
    pub row_column_of_split: BTreeMap<String, String>,
    pub scroll_areas: BTreeMap<String, ScrollArea>,
    pub scroll_area_of_pane: BTreeMap<String, String>,
    pub scroll_area_of_split: BTreeMap<String, String>,
    pub floating: Vec<String>,
    pub floating_cards: BTreeMap<String, Rect>,
}

impl ScreenGeometry {
    /// The memberwise init with every default: no panes, one snap offset at 0.
    fn new(viewport: Size, content_width: f64, is_columns: bool) -> Self {
        Self {
            viewport,
            panes: BTreeMap::new(),
            dividers: Vec::new(),
            columns: BTreeMap::new(),
            column_order: Vec::new(),
            column_edges: Vec::new(),
            gap_zones: Vec::new(),
            content_width,
            snap_offsets: vec![0.],
            is_columns,
            strip_min_x: 0.,
            strip_width: 0.,
            strip_min_y: 0.,
            strip_height: 0.,
            uncovered_min_x: 0.,
            uncovered_max_x: 0.,
            uncovered_min_y: 0.,
            uncovered_max_y: 0.,
            clip_min_x: 0.,
            clip_max_x: 0.,
            clip_min_y: 0.,
            clip_max_y: 0.,
            dock: Vec::new(),
            fixed_panes: BTreeSet::new(),
            frame_orientation: FrameOrientation::ColumnMajor,
            fixed_splits: BTreeSet::new(),
            row_stacks: BTreeMap::new(),
            row_edges: Vec::new(),
            row_column_of_pane: BTreeMap::new(),
            row_column_of_split: BTreeMap::new(),
            scroll_areas: BTreeMap::new(),
            scroll_area_of_pane: BTreeMap::new(),
            scroll_area_of_split: BTreeMap::new(),
            floating: Vec::new(),
            floating_cards: BTreeMap::new(),
        }
    }

    /// `compute(_:viewport:style:scale:)`.
    pub fn compute(
        layout: &ScreenLayout,
        viewport: Size,
        style: &ScreenStyle,
        scale: f64,
    ) -> ScreenGeometry {
        match layout {
            ScreenLayout::Splits(root) => {
                let mut geometry = ScreenGeometry::new(viewport, viewport.width, false);
                geometry.strip_width = viewport.width;
                geometry.strip_height = viewport.height;
                geometry.uncovered_max_x = viewport.width;
                geometry.uncovered_max_y = viewport.height;
                geometry.clip_max_x = viewport.width;
                geometry.clip_max_y = viewport.height;
                let frame = Rect::new(0., 0., viewport.width, viewport.height);
                let result = geometry.layout_tree(root, frame, style, scale);
                geometry.panes = result.panes;
                geometry.dividers = result.dividers;
                geometry
            }
            ScreenLayout::Columns(all) => {
                if style.prototype.model != PrototypeModel::Off
                    && let Some(prototype) = prototype_geometry(all, viewport, style, scale)
                {
                    return prototype;
                }
                Self::compute_columns(all, viewport, style, scale)
            }
        }
    }

    fn compute_columns(
        all: &[Column],
        viewport: Size,
        style: &ScreenStyle,
        scale: f64,
    ) -> ScreenGeometry {
        let chrome = style.chrome();
        let gap = chrome.strip_gap();
        let edges: Vec<Option<DockEdge>> =
            all.iter().map(|column| column.dock.map(|dock| dock.edge)).collect();
        let parts = dock_strip::parts(&edges);
        let dock = |index: Option<usize>, band: bool| {
            index.map(|index| {
                let column = &all[index];
                let minimum = column.minimum_size(style);
                Dock {
                    column: column.id.clone(),
                    mode: column.dock.map(|dock| dock.mode),
                    edge: column.dock.map(|dock| dock.edge),
                    width: column.width,
                    minimum_extent: if band { minimum.height } else { minimum.width },
                }
            })
        };
        let docks = Docks {
            left: dock(parts.left, false),
            right: dock(parts.right, false),
            top: dock(parts.top, true),
            bottom: dock(parts.bottom, true),
        };
        let placement = dock_strip::place(&docks, viewport, gap, style.frame_orientation, scale);
        let columns: Vec<&Column> = parts.scrolling.iter().map(|&index| &all[index]).collect();
        let widths: Vec<f64> =
            columns.iter().map(|column| if parts.lone { 1. } else { column.width }).collect();
        let minimums: Vec<f64> =
            columns.iter().map(|column| column.minimum_size(style).width).collect();
        let strip_viewport = Size { width: placement.strip_width, height: placement.strip_height };
        let (mut frames, mut content_width) =
            column_strip::frames(&widths, strip_viewport, gap, scale, &minimums);
        if placement.leading_inset > 0.
            || placement.trailing_inset > 0.
            || placement.strip_min_y > 0.
        {
            frames = frames
                .iter()
                .map(|frame| frame.offset_by(placement.leading_inset, placement.strip_min_y))
                .collect();
            content_width += placement.leading_inset + placement.trailing_inset;
        }
        let mut geometry = ScreenGeometry::new(viewport, content_width, true);
        geometry.strip_min_x = placement.strip_min_x;
        geometry.strip_width = placement.strip_width;
        geometry.strip_min_y = placement.strip_min_y;
        geometry.strip_height = placement.strip_height;
        geometry.uncovered_min_x = placement.uncovered_min_x;
        geometry.uncovered_max_x = placement.uncovered_max_x;
        geometry.uncovered_min_y = placement.uncovered_min_y;
        geometry.uncovered_max_y = placement.uncovered_max_y;
        geometry.clip_min_x = placement.clip_min_x;
        geometry.clip_max_x = placement.clip_max_x;
        geometry.clip_min_y = placement.clip_min_y;
        geometry.clip_max_y = placement.clip_max_y;
        geometry.dock = placement.dock.clone();
        geometry.frame_orientation = style.frame_orientation;
        let (strip_y, strip_h) = (placement.strip_min_y, placement.strip_height);
        let edge_hit = chrome.column_edge_hit_thickness();
        let drop_width = swift_max(gap, style.new_column_drop_width);
        let first_gap_mid = frames.first().map_or(gap, Rect::min_x) - gap / 2.;
        geometry.gap_zones.push(GapZone {
            after: None,
            frame: Rect::new(first_gap_mid - drop_width / 2., strip_y, drop_width, strip_h),
        });
        for (column, &frame) in columns.iter().zip(&frames) {
            geometry.columns.insert(column.id.clone(), frame);
            geometry.column_order.push(column.id.clone());
            let result = geometry.layout_content(column, frame, style, scale);
            geometry.panes.extend(result.panes);
            geometry.dividers.extend(result.dividers);
            let gap_mid = frame.max_x() + gap / 2.;
            geometry.column_edges.push(ColumnEdge {
                column: column.id.clone(),
                column_frame: frame,
                hit_frame: DividerBand::new(
                    SplitAxis::Horizontal,
                    gap_mid,
                    chrome.column_edge_line_thickness(),
                    edge_hit,
                    strip_y,
                    strip_h,
                    scale,
                )
                .hit,
                dock_edge: None,
                axis: SplitAxis::Horizontal,
            });
            geometry.gap_zones.push(GapZone {
                after: Some(column.id.clone()),
                frame: Rect::new(gap_mid - drop_width / 2., strip_y, drop_width, strip_h),
            });
        }
        geometry.snap_offsets =
            column_strip::snap_offsets(&frames, content_width, placement.strip_width, gap);
        for entry in &placement.dock {
            let Some(column) = all.iter().find(|column| column.id == entry.column) else {
                continue;
            };
            geometry.add_dock(column, entry, style, scale);
        }
        geometry
    }

    /// `maxOffset`.
    pub fn max_offset(&self) -> f64 {
        column_strip::max_offset(self.content_width, self.strip_width)
    }

    /// `addDock`: a docked column's content at its fixed frame, with its handle on the strip gap beside
    /// its inner edge.
    fn add_dock(&mut self, column: &Column, entry: &DockFrame, style: &ScreenStyle, scale: f64) {
        let result = self.layout_content(column, entry.frame, style, scale);
        self.columns.insert(column.id.clone(), entry.frame);
        for (pane, rect) in result.panes {
            self.fixed_panes.insert(pane.clone());
            self.panes.insert(pane, rect);
        }
        self.fixed_splits.extend(result.dividers.iter().map(|divider| divider.id.clone()));
        self.dividers.extend(result.dividers);
        let chrome = style.chrome();
        let gap = chrome.strip_gap();
        let axis = if entry.edge.is_band() { SplitAxis::Vertical } else { SplitAxis::Horizontal };
        let center = match entry.edge {
            DockEdge::Left => entry.frame.max_x() + gap / 2.,
            DockEdge::Right => entry.frame.min_x() - gap / 2.,
            DockEdge::Top => entry.frame.max_y() + gap / 2.,
            DockEdge::Bottom => entry.frame.min_y() - gap / 2.,
        };
        let horizontal = axis == SplitAxis::Horizontal;
        let band = DividerBand::new(
            axis,
            center,
            chrome.column_edge_line_thickness(),
            chrome.column_edge_hit_thickness(),
            if horizontal { entry.frame.min_y() } else { entry.frame.min_x() },
            if horizontal { entry.frame.height() } else { entry.frame.width() },
            scale,
        );
        self.column_edges.push(ColumnEdge {
            column: column.id.clone(),
            column_frame: entry.frame,
            hit_frame: band.hit,
            dock_edge: Some(entry.edge),
            axis,
        });
    }

    /// `layoutContent(of:in:style:scale:)`: a column's tree, or its rows stacked top to bottom with each
    /// row's tree inside. Rows turned off fit the column and never scroll.
    fn layout_content(
        &mut self,
        column: &Column,
        frame: Rect,
        style: &ScreenStyle,
        scale: f64,
    ) -> SplitLayout {
        if !column.has_rows() {
            return self.layout_tree(&column.root, frame, style, scale);
        }
        let split = style.split();
        let rows: Vec<Row> =
            column.rows.iter().map(|row| Row { id: row.id.clone(), height: row.height }).collect();
        let minimums: Vec<f64> = column
            .rows
            .iter()
            .map(|row| split_layout::minimum_size(&row.root, &split).height)
            .collect();
        let stack = RowStack::compute(
            &column.id,
            &rows,
            &minimums,
            frame,
            style.chrome().strip_gap(),
            !style.rows_enabled,
            scale,
        );
        self.row_edges.extend(stack.edges(
            style.divider_thickness,
            style.chrome().column_edge_hit_thickness(),
            scale,
        ));
        let mut result = SplitLayout::default();
        for (row, placed) in column.rows.iter().zip(&stack.rows) {
            let inner = self.layout_tree(&row.root, placed.frame, style, scale);
            result.panes.extend(inner.panes);
            result.dividers.extend(inner.dividers);
        }
        self.row_stacks.insert(column.id.clone(), stack);
        for pane in result.panes.keys() {
            self.row_column_of_pane.insert(pane.clone(), column.id.clone());
        }
        for divider in &result.dividers {
            self.row_column_of_split.insert(divider.id.clone(), column.id.clone());
        }
        result
    }

    /// `layoutTree(_:in:style:scale:)`: one top-level tree in `frame`, or, when it cannot fit and scroll
    /// areas are on, at its minimum width as a scroll area shown through `frame`.
    fn layout_tree(
        &mut self,
        root: &SplitNode,
        frame: Rect,
        style: &ScreenStyle,
        scale: f64,
    ) -> SplitLayout {
        let split = style.split();
        let Some((id, content)) = column_strip::scroll_area_overflow(
            root,
            frame,
            &split,
            style.scroll_areas_enabled,
            scale,
        ) else {
            return split_layout::layout(root, frame, &split, scale);
        };
        let result = split_layout::layout(root, content, &split, scale);
        let cells = column_strip::scroll_area_cells(root)
            .into_iter()
            .map(|cell| {
                let panes = cell.panes();
                let pane_frames: BTreeMap<String, Rect> = panes
                    .iter()
                    .filter_map(|pane| result.panes.get(pane).map(|rect| (pane.clone(), *rect)))
                    .collect();
                let frame = panes
                    .iter()
                    .filter_map(|pane| pane_frames.get(pane))
                    .fold(None, |acc, rect| Some(union(acc, *rect)));
                ScrollCell { panes, frame, pane_frames }
            })
            .collect();
        let area = ScrollArea {
            id: id.clone(),
            window: frame,
            content_width: content.width(),
            panes: root.panes(),
            cells,
            splits: root.splits(),
        };
        for pane in &area.panes {
            self.scroll_area_of_pane.insert(pane.clone(), id.clone());
        }
        for split in &area.splits {
            self.scroll_area_of_split.insert(split.clone(), id.clone());
        }
        self.scroll_areas.insert(id, area);
        result
    }

    /// `shiftingRows(_:)`: each row column's content moved up by its vertical offset. Column frames and
    /// row stacks stay.
    pub fn shifting_rows(&self, offsets: &BTreeMap<String, f64>) -> ScreenGeometry {
        let live: BTreeMap<&String, f64> = offsets
            .iter()
            .filter(|(column, dy)| **dy != 0. && self.row_stacks.contains_key(*column))
            .map(|(column, dy)| (column, *dy))
            .collect();
        if live.is_empty() {
            return self.clone();
        }
        let mut shifted = self.clone();
        for (pane, column) in &self.row_column_of_pane {
            let (Some(dy), Some(rect)) = (live.get(column), self.panes.get(pane)) else { continue };
            shifted.panes.insert(pane.clone(), rect.offset_by(0., -dy));
        }
        shifted.dividers = self
            .dividers
            .iter()
            .map(|divider| {
                let dy = self.row_column_of_split.get(&divider.id).and_then(|c| live.get(c));
                let Some(&dy) = dy else { return divider.clone() };
                let mut moved = divider.clone();
                moved.frame = divider.frame.offset_by(0., -dy);
                moved.hit_frame = divider.hit_frame.offset_by(0., -dy);
                moved.container = divider.container.offset_by(0., -dy);
                moved
            })
            .collect();
        shifted.row_edges = self
            .row_edges
            .iter()
            .map(|edge| {
                let Some(&dy) = live.get(&edge.column) else { return edge.clone() };
                let mut moved = edge.clone();
                moved.hit_frame = edge.hit_frame.offset_by(0., -dy);
                moved
            })
            .collect();
        shifted
    }

    /// `scrolls(pane:)`.
    pub fn scrolls(&self, pane: &str) -> bool {
        !self.fixed_panes.contains(pane)
    }

    /// `placingFloating(_:scale:)`: `list` (back to front) above the tiled panes, each card at its
    /// fractions of the viewport and its pane inside the card.
    pub fn placing_floating(&self, list: &[FloatingPane], scale: f64) -> ScreenGeometry {
        if list.is_empty() {
            return self.clone();
        }
        let mut placed = self.clone();
        for entry in list {
            if placed.floating_cards.contains_key(&entry.pane) {
                continue;
            }
            let card = entry.rect(self.viewport, scale);
            placed.floating_cards.insert(entry.pane.clone(), card);
            placed.floating.push(entry.pane.clone());
            placed.panes.insert(entry.pane.clone(), floating_pane_rect(card));
            placed.fixed_panes.insert(entry.pane.clone());
        }
        placed
    }

    /// `viewShift(offset:)`: the view x of strip content x at scroll `offset`.
    pub fn view_shift(&self, offset: f64) -> f64 {
        self.strip_min_x - offset
    }

    /// `dockFrame(containing:)`: the docked column holding `pane`.
    pub fn dock_frame(&self, pane: &str) -> Option<&DockFrame> {
        if !self.fixed_panes.contains(pane) || self.floating_cards.contains_key(pane) {
            return None;
        }
        let rect = self.scroll_area_window(pane).or_else(|| self.panes.get(pane).copied())?;
        let center = Point::new(rect.mid_x(), rect.mid_y());
        self.dock.iter().find(|entry| entry.frame.contains(center))
    }

    /// `orderedColumnFrames`.
    pub fn ordered_column_frames(&self) -> Vec<Rect> {
        self.column_order.iter().filter_map(|id| self.columns.get(id).copied()).collect()
    }

    /// `navigationRect(of:)`: inside a scroll area, the pane mapped into the area's window in
    /// proportion; else its frame.
    pub fn navigation_rect(&self, pane: &str) -> Option<Rect> {
        let rect = *self.panes.get(pane)?;
        let Some(area) =
            self.scroll_area_of_pane.get(pane).and_then(|id| self.scroll_areas.get(id))
        else {
            return Some(rect);
        };
        Some(column_strip::scroll_area_navigation_rect(area.window, area.content_width, rect))
    }

    /// `scrollAreaWindow(of:)`.
    pub fn scroll_area_window(&self, pane: &str) -> Option<Rect> {
        let id = self.scroll_area_of_pane.get(pane)?;
        self.scroll_areas.get(id).map(|area| area.window)
    }

    /// `shiftingAreas(_:)`: each scroll area's panes and dividers moved left by its offset and each pane
    /// cut to its window; a pane wholly outside keeps a zero-wide rect at the window's nearer edge.
    pub fn shifting_areas(&self, offsets: &BTreeMap<String, f64>) -> ScreenGeometry {
        if self.scroll_areas.is_empty() {
            return self.clone();
        }
        let live: BTreeMap<&String, f64> = offsets
            .iter()
            .filter(|(id, dx)| **dx != 0. && self.scroll_areas.contains_key(*id))
            .map(|(id, dx)| (id, *dx))
            .collect();
        let mut shifted = self.clone();
        for (pane, id) in &self.scroll_area_of_pane {
            let (Some(area), Some(rect)) = (self.scroll_areas.get(id), self.panes.get(pane)) else {
                continue;
            };
            let window = area.window;
            let moved = rect.offset_by(-live.get(id).copied().unwrap_or(0.), 0.);
            let shown = match moved.intersection(&window) {
                Some(shown) if shown.width() > 0. => shown,
                _ => Rect::new(
                    if moved.max_x() <= window.min_x() { window.min_x() } else { window.max_x() },
                    moved.min_y(),
                    0.,
                    moved.height(),
                ),
            };
            shifted.panes.insert(pane.clone(), shown);
        }
        if live.is_empty() {
            return shifted;
        }
        shifted.dividers = self
            .dividers
            .iter()
            .map(|divider| {
                let dx = self.scroll_area_of_split.get(&divider.id).and_then(|a| live.get(a));
                let Some(&dx) = dx else { return divider.clone() };
                let mut moved = divider.clone();
                moved.frame = divider.frame.offset_by(-dx, 0.);
                moved.hit_frame = divider.hit_frame.offset_by(-dx, 0.);
                moved.container = divider.container.offset_by(-dx, 0.);
                moved
            })
            .collect();
        shifted
    }

    /// `canvas(_:visible:)`: every pane at its canvas frame, with no dividers, columns or docks.
    pub fn canvas(frames: &BTreeMap<String, Rect>, visible: Rect) -> ScreenGeometry {
        let size = Size { width: visible.width(), height: visible.height() };
        let mut geometry = ScreenGeometry::new(size, visible.width(), false);
        geometry.panes = frames.clone();
        geometry.strip_width = visible.width();
        geometry.strip_height = visible.height();
        geometry.uncovered_min_x = visible.min_x();
        geometry.uncovered_max_x = visible.max_x();
        geometry.uncovered_min_y = visible.min_y();
        geometry.uncovered_max_y = visible.max_y();
        geometry.clip_min_x = visible.min_x();
        geometry.clip_max_x = visible.max_x();
        geometry.clip_min_y = visible.min_y();
        geometry.clip_max_y = visible.max_y();
        geometry
    }
}

/// `LayoutModelPrototype.geometry(_:viewport:style:scale:)`: `None` when the screen has nothing to
/// reinterpret and the caller keeps the real layout.
pub fn prototype_geometry(
    columns: &[Column],
    viewport: Size,
    style: &ScreenStyle,
    scale: f64,
) -> Option<ScreenGeometry> {
    let mut plain = *style;
    plain.prototype = PrototypeSettings::default();
    match style.prototype.model {
        PrototypeModel::Off => None,
        PrototypeModel::FrameDocks => {
            let docks = frame_docks(columns, &style.prototype);
            if docks == columns {
                return None;
            }
            plain.frame_orientation = style.prototype.orientation;
            Some(ScreenGeometry::compute(&ScreenLayout::Columns(docks), viewport, &plain, scale))
        }
        PrototypeModel::Grid => grid(columns, viewport, &plain, scale),
    }
}

/// `frameDocks`: the right dock (synthesized when there is none) becomes the top or bottom dock.
pub fn frame_docks(columns: &[Column], settings: &PrototypeSettings) -> Vec<Column> {
    let mut result = synthesized_docks(columns, settings.dock_mode);
    let band = match settings.dock_edge {
        PrototypeDockEdge::Top => DockEdge::Top,
        PrototypeDockEdge::Bottom => DockEdge::Bottom,
    };
    if let Some(column) = result
        .iter_mut()
        .find(|column| column.dock.is_some_and(|dock| dock.edge == DockEdge::Right))
        && let Some(dock) = column.dock
    {
        column.dock = Some(DockColumn { edge: band, mode: dock.mode, role: None });
    }
    result
}

/// `synthesizedDocks`: without a right dock the last strip column becomes it, and with two or more
/// strip columns left the first becomes the left dock. Real docked columns stay.
pub fn synthesized_docks(columns: &[Column], mode: DockMode) -> Vec<Column> {
    let mut result = columns.to_vec();
    let edges: Vec<Option<DockEdge>> =
        columns.iter().map(|column| column.dock.map(|dock| dock.edge)).collect();
    let parts = dock_strip::parts(&edges);
    let mut scrolling: Vec<String> =
        parts.scrolling.iter().map(|&index| columns[index].id.clone()).collect();
    let mut set = |id: &str, edge: DockEdge| {
        if let Some(column) = result.iter_mut().find(|column| column.id == id) {
            column.dock = Some(DockColumn { edge, mode, role: None });
        }
    };
    if parts.right.is_none()
        && scrolling.len() >= 2
        && let Some(last) = scrolling.pop()
    {
        set(&last, DockEdge::Right);
    }
    if parts.left.is_none()
        && scrolling.len() >= 2
        && let Some(first) = scrolling.first()
    {
        set(first, DockEdge::Left);
    }
    result
}

/// `grid`: columns keep their strip frames; pane `i` of every column sits in grid row `i`, all rows
/// one height, and in-column dividers go away.
pub fn grid(
    columns: &[Column],
    viewport: Size,
    style: &ScreenStyle,
    scale: f64,
) -> Option<ScreenGeometry> {
    let mut geometry =
        ScreenGeometry::compute(&ScreenLayout::Columns(columns.to_vec()), viewport, style, scale);
    let scrolling: Vec<&Column> =
        columns.iter().filter(|column| geometry.column_order.contains(&column.id)).collect();
    let rows = scrolling.iter().map(|column| column.root.panes().len()).max().unwrap_or(0);
    if rows <= 1 {
        return None;
    }
    let gap = style.chrome().strip_gap();
    let row_height =
        round_to_pixel((viewport.height - gap * (rows - 1) as f64) / rows as f64, scale);
    for column in scrolling {
        let Some(frame) = geometry.columns.get(&column.id).copied() else { continue };
        for (index, pane) in column.root.panes().into_iter().enumerate() {
            geometry.panes.insert(
                pane,
                Rect::new(
                    frame.min_x(),
                    index as f64 * (row_height + gap),
                    frame.width(),
                    row_height,
                ),
            );
        }
    }
    let fixed = geometry.fixed_splits.clone();
    geometry.dividers.retain(|divider| fixed.contains(&divider.id));
    Some(geometry)
}

/// `SplitRefusal`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SplitRefusal {
    NotEnoughRoom,
}

/// `SplitPlacement`: `"split"`, `"newColumn"` or `{"refused": "notEnoughRoom"}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SplitPlacement {
    Split,
    NewColumn,
    Refused(SplitRefusal),
}

/// `SplitRoom.placement(splitting:axis:in:viewport:style:removing:)`: where a split of `pane` goes.
/// An unknown pane or an unmeasured viewport splits: the daemon decides.
pub fn split_placement(
    pane: &str,
    axis: SplitAxis,
    layout: &ScreenLayout,
    viewport: Size,
    style: &ScreenStyle,
    removing: Option<&str>,
) -> SplitPlacement {
    const REFUSED: SplitPlacement = SplitPlacement::Refused(SplitRefusal::NotEnoughRoom);
    if viewport.width <= 0. || viewport.height <= 0. {
        return SplitPlacement::Split;
    }
    let removing = if removing == Some(pane) { None } else { removing };
    match layout {
        ScreenLayout::Splits(root) => {
            if !root.contains(pane) {
                return SplitPlacement::Split;
            }
            let need = room_minimum_size(pane, axis, root, removing, style);
            if fits(need, viewport, style.scroll_areas_enabled) {
                SplitPlacement::Split
            } else {
                REFUSED
            }
        }
        ScreenLayout::Columns(columns) => {
            let Some(column) = columns.iter().find(|column| column.root.contains(pane)) else {
                return SplitPlacement::Split;
            };
            let geometry = ScreenGeometry::compute(layout, viewport, style, 2.);
            let row = if column.has_rows() { column.row_containing(pane) } else { None };
            let frame = row
                .and_then(|row| {
                    let stack = geometry.row_stacks.get(&column.id)?;
                    stack.rows.iter().find(|placed| placed.id == row.id).map(|placed| placed.frame)
                })
                .or_else(|| geometry.columns.get(&column.id).copied());
            let container = Size {
                width: frame.map_or(viewport.width, |frame| frame.width()),
                height: frame.map_or(viewport.height, |frame| frame.height()),
            };
            let tree = row.map_or(&column.root, |row| &row.root);
            let need = room_minimum_size(pane, axis, tree, removing, style);
            if fits(need, container, false) {
                return SplitPlacement::Split;
            }
            if geometry.fixed_panes.contains(pane) {
                return if fits(need, container, style.scroll_areas_enabled) {
                    SplitPlacement::Split
                } else {
                    REFUSED
                };
            }
            let strip = Size {
                width: swift_max(1., viewport.width - style.chrome().strip_gap() * 2.),
                height: viewport.height,
            };
            if axis == SplitAxis::Horizontal
                && fits(style.split().minimum_pane_size(), strip, false)
            {
                return SplitPlacement::NewColumn;
            }
            REFUSED
        }
    }
}

/// `SplitRoom.minimumSize(splitting:axis:in:removing:style:)`: the tree's minimum after `removing`
/// leaves and `pane` splits.
pub fn room_minimum_size(
    pane: &str,
    axis: SplitAxis,
    tree: &SplitNode,
    removing: Option<&str>,
    style: &ScreenStyle,
) -> Size {
    let pruned = removing.and_then(|gone| tree.removing(gone)).unwrap_or_else(|| tree.clone());
    let split = pruned.replacing_leaf(pane, &|leaf| SplitNode::Split {
        split: "room-check".into(),
        axis,
        ratio: 0.5,
        a: Box::new(leaf.clone()),
        b: Box::new(SplitNode::Leaf { pane: "room-check".into() }),
    });
    split_layout::minimum_size(&split, &style.split())
}

/// `SplitRoom.fits(_:in:scrolls:)`: `scrolls` means only the height must fit.
pub fn fits(size: Size, container: Size, scrolls: bool) -> bool {
    (scrolls || size.width <= container.width + 0.5) && size.height <= container.height + 0.5
}
